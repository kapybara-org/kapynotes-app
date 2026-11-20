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
import '../checklist_pie.dart';
import '../context_menu.dart';
import '../sidebar_timestamp.dart';
import 'task_choice.dart';
import 'task_choice_cards.dart';
import 'task_details_sheet.dart';
import 'task_marks.dart';
import 'tasks_controller.dart';

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
class TasksScreen extends StatefulWidget {
  const TasksScreen({
    super.key,
    required this.controller,
    required this.filter,
    required this.addFocus,
    required this.labelOf,
    required this.onOpenNote,
    required this.onOpenDone,
    this.images,
    this.newTaskShortcut,
    this.phone = false,
    this.sheet = false,
    this.scrollController,
  });

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

  /// A note's name as a task's mark shows it.
  final String Function(Note note) labelOf;
  final ValueChanged<String> onOpenNote;

  /// Opens the Done view, from the evening's "N finished today".
  final VoidCallback onOpenDone;

  /// Where a task's picture is stored, so Do now and the sheet can show it.
  /// Null in a test that does not draw pictures.
  final BlobStore? images;

  /// Printed on the add row at rest.
  final String? newTaskShortcut;

  @override
  State<TasksScreen> createState() => TasksScreenState();
}

class TasksScreenState extends State<TasksScreen> {
  final _words = TextEditingController();

  /// Tasks a phone checked off on this visit, by the place they held in the
  /// rest of the list, so their rows stay, struck through, until the screen
  /// is left.
  final Map<String, (int, TaskItem)> _ticked = {};

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
      _tasks.forgetPair();
      _targetChosen = false;
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
  String? get _noteId => widget.filter.noteId;

  List<TaskItem> _open(TaskBoard board) => board.openIn(_noteId);

  TaskChoice get _choice => _tasks.choiceIn(_noteId);

  /// Choose again: every choice cleared, from the first pair.
  void chooseAgain() => _tasks.chooseAgain(noteId: _noteId);

  /// Done on Do now, from its button or ⌘↵.
  void completeDoNow() {
    if (widget.filter.done) return;
    if (_choice.stage case DoNowStage(:final item)) {
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

  /// esc: start with your choice so far, while Start with shows.
  bool startEarly() {
    final pair = _pair;
    if (pair == null || pair.pairsLeft == 0) return false;
    _tasks.startWith(pair.left);
    return true;
  }

  String? get _addInto => _targetChosen ? _target : _noteId;

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
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this task?'),
        content: Text('Its line comes out of “$label”. You can undo this.'),
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
        content: const Text('Task removed'),
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
      final board = _tasks.read();
      return LayoutBuilder(
        builder: (context, constraints) {
          final phone = widget.phone;
          final width = phone
              ? constraints.maxWidth - 42
              : math.min(680.0, constraints.maxWidth - 48);
          return SingleChildScrollView(
            controller: widget.scrollController,
            padding: EdgeInsets.only(
              top: phone ? 0 : 20,
              bottom: phone ? 120 : 48,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(
                  left: (constraints.maxWidth - width) / 2,
                ),
                child: SizedBox(
                  width: width,
                  child: widget.filter.done
                      ? _done(board)
                      : _withSheet(board, _today(board)),
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

  String? _labelOf(TaskBoard board, TaskItem item) =>
      board.isHome(item) ? null : widget.labelOf(item.note);

  Widget _row(TaskBoard board, TaskItem item, {bool upNext = false}) {
    if (widget.phone) {
      return _PhoneTaskRow(
        key: ValueKey(item.id),
        item: item,
        done: false,
        now: _tasks.now(),
        label: _labelOf(board, item),
        menu: _menuFor(item, upNext: upNext),
        onTick: () => _tick(item, done: true),
        onOpen: () => _openSheet(item),
        onKeep: () => _tasks.keep(item),
        onRemove: () => unawaited(_remove(item)),
      );
    }
    return _TaskRow(
      key: ValueKey(item.id),
      item: item,
      now: _tasks.now(),
      label: _labelOf(board, item),
      wash: item.id == _washId,
      menu: _menuFor(item, upNext: upNext),
      onTick: () => unawaited(_tasks.setDone(item, done: true)),
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
    final today = DateTime(now.year, now.month, now.day);
    final finished = [
      for (final item in board.done.reversed)
        if ((_noteId == null || item.note.id == _noteId) &&
            !item.doneAt!.isBefore(today))
          item,
    ];
    final choice = _choice;
    final stage = choice.stage;
    String? labelOf(TaskItem item) => _labelOf(board, item);
    final rest = phone ? _phoneRest(board, choice.rest) : null;
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
          _AddRow(
            phone: phone,
            controller: _words,
            focus: widget.addFocus,
            shortcut: widget.newTaskShortcut,
            target: _addInto == null ? null : _tasks.notes.byId(_addInto),
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
                    padding: EdgeInsets.only(left: phone ? 14 : 12, top: 8),
                    child: Text(
                      'Added to the end of the list',
                      key: const ValueKey('tasks-added-notice'),
                      style: taskText(12, 16, ink.sage, 500),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
        const SizedBox(height: 14),
        switch (stage) {
          EmptyStage() => Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: _ticked.isEmpty
                ? Text(
                    'Nothing on the list.',
                    style: taskText(13, 18, ink.quiet),
                  )
                : null,
          ),
          PairStage() => TaskPairCard(
            pair: stage,
            now: now,
            labelOf: labelOf,
            justDone: _tasks.justDone,
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
            onDone: () => unawaited(_tasks.finish(item, noteId: _noteId)),
          ),
          EveningStage(:final left) => TaskEveningCard(
            finished: finished.length,
            phone: phone,
            onKeepGoing: _tasks.keepGoing,
            left: [for (final item in left) _row(board, item)],
          ),
        },
        if (stage is EveningStage && finished.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TaskFinishedLine(
              finished: finished,
              onPressed: widget.onOpenDone,
            ),
          ),
        if (choice.upNext.isNotEmpty) ...[
          _Heading('Up next', phone: phone),
          for (final item in choice.upNext) _row(board, item, upNext: true),
        ],
        if (choice.rest.isNotEmpty || (rest?.isNotEmpty ?? false))
          Container(
            margin: EdgeInsets.only(
              top: choice.upNext.isEmpty ? (phone ? 12 : 12) : (phone ? 4 : 0),
            ),
            padding: EdgeInsets.only(top: choice.upNext.isEmpty ? 0 : 8),
            decoration: BoxDecoration(
              border: choice.upNext.isEmpty
                  ? null
                  : Border(top: BorderSide(color: ink.hairline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rest != null)
                  for (final (item, done) in rest)
                    done
                        ? _PhoneTaskRow(
                            key: ValueKey(item.id),
                            item: item,
                            done: true,
                            now: now,
                            label: labelOf(item),
                            menu: const [],
                            onTick: () => _tick(item, done: false),
                            onOpen: () => _openSheet(item),
                            onKeep: () {},
                            onRemove: () {},
                          )
                        : _row(board, item)
                else
                  for (final item in choice.rest) _row(board, item),
              ],
            ),
          ),
      ],
    );
  }

  /// The rest of the list, with the tasks a phone checked off on this visit
  /// back in the places they held.
  List<(TaskItem, bool)> _phoneRest(TaskBoard board, List<TaskItem> rest) {
    final rows = [for (final item in rest) (item, false)];
    final ids = {for (final item in board.open) item.id};
    final ticked = _ticked.values.toList()..sort((a, b) => a.$1 - b.$1);
    for (final (index, item) in ticked) {
      if (ids.contains(item.id)) continue;
      rows.insert(math.min(index, rows.length), (item, true));
    }
    return rows;
  }

  void _tick(TaskItem item, {required bool done}) {
    final rest = _choice.rest;
    setState(() {
      if (done) {
        final at = rest.indexWhere((row) => row.id == item.id);
        _ticked[item.id] = (at < 0 ? 0 : at, item);
      } else {
        _ticked.remove(item.id);
      }
    });
    unawaited(_tasks.setDone(item, done: done));
  }

  /// The notes the add row can write into: the ones with tasks, then the
  /// note for tasks with no note leads as "No note".
  List<Note> _pickerNotes(TaskBoard board) {
    final seen = <String>{?board.home?.id};
    return [
      for (final item in [...board.open, ...board.done])
        if (seen.add(item.note.id)) item.note,
    ];
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    'Done',
                    style: handStyle(
                      32,
                      40,
                      FontWeight.w700,
                      palette.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${board.done.length} completed',
                    style: uiStyle(
                      13,
                      16,
                      FontWeight.w600,
                      palette.textTertiary,
                    ),
                  ),
                ],
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
              onUntick: () => unawaited(_tasks.setDone(item, done: false)),
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
        borderRadius: BorderRadius.circular(phone ? 10 : 9),
      ),
      child: Row(
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
                const SingleActivator(LogicalKeyboardKey.escape): focus.unfocus,
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
          ),
          if (!phone) ...[
            const SizedBox(width: 10),
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  focused ? '↵' : shortcut ?? '',
                  style: TextStyle(
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
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
  });

  final Note? target;
  final String Function(Note note) labelOf;
  final List<Note> choices;
  final ValueChanged<String?> onChoose;
  final bool chevron;

  /// Whether this sits in a phone's row, where a target is 44 pt tall.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final target = this.target;
    return Tooltip(
      message: 'Add to a note',
      child: InkWell(
        key: const ValueKey('tasks-note-picker'),
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(phone ? 8 : 6),
        onTap: () => _open(context),
        child: SizedBox(
          height: phone ? 44 : 28,
          child: Center(
            widthFactor: 1,
            child: Container(
              height: phone ? 30 : 28,
              constraints: const BoxConstraints(maxWidth: 200),
              padding: EdgeInsets.only(
                left: phone ? 10 : 9,
                right: phone ? 10 : 8,
              ),
              decoration: BoxDecoration(
                color: ink.lifted,
                borderRadius: BorderRadius.circular(phone ? 8 : 6),
              ),
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
  final DateTime now;

  /// The note's name on its mark; null for a task with no note.
  final String? label;

  /// Just added: a sage wash that fades.
  final bool wash;
  final List<TaskMenuChoice?> menu;
  final VoidCallback onTick;
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
    final stale = taskIsStale(item, widget.now);
    final quiet = taskText(12, 16, ink.quiet);
    final touch = !AppPlatform.hasPointer;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 44 : 36),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _RowBox(onPressed: widget.onTick, label: item.words),
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
                  style: taskText(13, 18, stale ? ink.quiet : ink.text),
                ),
              ),
            ),
            if (stale) ...[
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('Still want this?', style: quiet),
              ),
              _RowButton(label: 'Keep', strong: true, onPressed: widget.onKeep),
              const SizedBox(width: 4),
              _RowButton(label: 'Remove', onPressed: widget.onRemove),
            ] else if (_hovered) ...[
              const SizedBox(width: 10),
              Text(
                'Added ${SidebarTimestamp.shortDay(DateTime.fromMillisecondsSinceEpoch(item.entry.addedAt), now: widget.now)}',
                style: quiet,
              ),
            ],
            if (_hovered && !stale) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'More',
                child: InkWell(
                  key: _more,
                  onTap: () {
                    final box =
                        _more.currentContext!.findRenderObject()! as RenderBox;
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
            if (item.entry.enteredAt != 0 && !stale && !_hovered)
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
            if (!_hovered && !stale) TaskDetailsIcon(item: item),
            const SizedBox(width: 16),
            SizedBox(
              width: 150,
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
          onSecondaryTapUp: (details) => _openMenu(details.globalPosition),
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
                    : _hovered
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
    this.phone = false,
  });

  final VoidCallback onPressed;
  final String label;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final size = phone ? 20.0 : 16.0;
    return Semantics(
      checked: false,
      label: label,
      button: true,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: phone ? 44 : 20,
          height: phone ? 44 : 28,
          child: Align(
            alignment: phone ? Alignment.centerLeft : Alignment.center,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                border: Border.all(color: ink.quiet, width: phone ? 1.5 : 1.25),
                borderRadius: BorderRadius.circular(phone ? 5 : 4),
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
  final VoidCallback onUntick;
  final VoidCallback onOpenNote;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = this.label;
    return SizedBox(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _Box(done: true, onPressed: onUntick, label: item.words),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
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
                    NoteMark(
                      note: item.note,
                      label: label,
                      onPressed: onOpenNote,
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                SidebarTimestamp.clock(item.doneAt!),
                textAlign: TextAlign.right,
                style: uiStyle(12.5, 16, FontWeight.w500, palette.textTertiary),
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
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      checked: done,
      label: label,
      button: true,
      child: InkResponse(
        onTap: onPressed,
        radius: 16,
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
    return Padding(
      padding: EdgeInsets.only(top: sheet ? 0 : 22, bottom: sheet ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Today',
              style: TextStyle(
                fontFamily: AppFonts.title,
                fontFamilyFallback: AppFonts.uiFallback,
                fontSize: 19,
                height: 24 / 19,
                color: ink.text,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              SidebarTimestamp.dayAndDate(now),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: taskText(13, 16, ink.quiet),
            ),
          ),
          Text(
            '$done of $total done',
            key: const ValueKey('tasks-done-count'),
            style: taskText(
              13,
              16,
              ink.quiet,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
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
  final List<TaskMenuChoice?> menu;
  final VoidCallback onTick;
  final VoidCallback onOpen;
  final VoidCallback onKeep;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final palette = context.palette;
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
                if (done)
                  Semantics(
                    checked: true,
                    label: item.words,
                    button: true,
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
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: ink.sage,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: KapyIcon(
                              KapyIcons.checkRounded,
                              size: 14,
                              strokeWidth: 2.2,
                              color: palette.paperColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  KeyedSubtree(
                    key: ValueKey('phone-task-box-${item.id}'),
                    child: _RowBox(
                      onPressed: onTick,
                      label: item.words,
                      phone: true,
                    ),
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
                          style:
                              taskText(
                                16,
                                22,
                                done || stale ? ink.quiet : ink.text,
                              ).copyWith(
                                decoration: done
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                        ),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          children: [
                            Text(label ?? 'No note', style: meta),
                            if (item.entry.enteredAt != 0 && !done)
                              KapyIcon(
                                KapyIcons.undoRounded,
                                size: 14,
                                color: ink.quiet,
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
        Text(
          SidebarTimestamp.dayAndDate(now),
          style: taskText(13, 18, ink.quiet),
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
      final total = done + board.openIn(filter.noteId).length;
      final chosen = controller.choiceIn(filter.noteId).chosen;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ChecklistPie(
            done: done,
            total: total,
            fill: ink.sage,
            check: context.palette.paperColor,
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
