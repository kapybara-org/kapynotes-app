import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/note.dart';
import '../../data/task_board.dart';
import '../context_menu.dart';
import '../editor/note_header.dart';
import '../keycap.dart';
import '../sidebar_timestamp.dart';
import '../tonal_button.dart';
import 'task_marks.dart';
import 'tasks_controller.dart';

/// The chord that finishes Do now, as its button prints it.
String get doneShortcutLabel => AppPlatform.isMacOS ? '⌘↵' : 'Ctrl+↵';

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
    required this.query,
    required this.addFocus,
    required this.labelOf,
    required this.onOpenNote,
    this.newTaskShortcut,
  });

  final TasksController controller;
  final TaskFilter filter;

  /// What the sidebar's field has narrowed the list to.
  final String query;
  final FocusNode addFocus;

  /// A note's name as a task's mark shows it.
  final String Function(Note note) labelOf;
  final ValueChanged<String> onOpenNote;

  /// Printed on the add row's keycap at rest.
  final String? newTaskShortcut;

  @override
  State<TasksScreen> createState() => TasksScreenState();
}

class TasksScreenState extends State<TasksScreen> {
  final _words = TextEditingController();

  /// Where the next scan starts after Do now was done or sent back: only
  /// tasks after it are asked about, until the next Pick again.
  int? _resumeAfter;

  /// The note the add row writes into, once chosen in its picker; until then
  /// the sidebar's filter decides.
  String? _target;
  bool _targetChosen = false;

  String? _washId;
  bool _notice = false;
  Timer? _noticeTimer;
  bool _allCandidates = false;
  String? _autoPicked;

  @override
  void initState() {
    super.initState();
    widget.addFocus.addListener(_focusChanged);
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
    widget.addFocus.removeListener(_focusChanged);
    _noticeTimer?.cancel();
    _words.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  TasksController get _tasks => widget.controller;

  List<TaskItem> _open(TaskBoard board) => board.openIn(widget.filter.noteId);

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
    if (item == null) return;
    _resumeAfter = item.entry.position;
    unawaited(_tasks.setDone(item, done: true));
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

  bool _matches(TaskItem item) {
    final terms = widget.query.toLowerCase().split(RegExp(r'\s+'));
    final words = item.words.toLowerCase();
    return terms.every((term) => term.isEmpty || words.contains(term));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final board = _tasks.read();
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(700.0, constraints.maxWidth - 48);
          return SingleChildScrollView(
            padding: const EdgeInsets.only(top: 20, bottom: 48),
            child: Center(
              child: SizedBox(
                width: width,
                child: widget.filter.done ? _done(board) : _today(board),
              ),
            ),
          );
        },
      );
    },
  );

  Widget _today(TaskBoard board) {
    final palette = context.palette;
    final now = _tasks.now();
    final open = _open(board);
    final doneToday = board.doneSince(
      DateTime(now.year, now.month, now.day),
      noteId: widget.filter.noteId,
    );
    final doNow = _doNow(open);
    final shown = open.where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 10, bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _TodayTitle(),
              const SizedBox(height: 10),
              NoteMetaRow(
                edited: SidebarTimestamp.fullDay(now),
                done: doneToday,
                tasks: doneToday + open.length,
                today: true,
              ),
            ],
          ),
        ),
        _AddRow(
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
                  padding: const EdgeInsets.only(left: 36, top: 8),
                  child: Text(
                    'Added to the end of the list',
                    key: const ValueKey('tasks-added-notice'),
                    style: uiStyle(13, 16, FontWeight.w500, palette.accentText),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 14),
        if (doNow != null)
          _DoNowCard(
            item: doNow,
            label: board.isHome(doNow) ? null : widget.labelOf(doNow.note),
            onOpenNote: () => widget.onOpenNote(doNow.note.id),
            onNotFinished: () => _notFinished(doNow),
            onDone: completeDoNow,
          )
        else if (open.isNotEmpty)
          _picker(board, open),
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
                style: uiStyle(12, 16, FontWeight.w600, palette.textTertiary),
              ),
            ],
          ),
        ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Text(
              open.isEmpty ? 'Nothing on the list.' : 'No tasks match.',
              style: uiStyle(14, 20, FontWeight.w500, palette.textTertiary),
            ),
          ),
        for (final item in shown)
          _TaskRow(
            key: ValueKey(item.id),
            item: item,
            now: _tasks.now(),
            label: board.isHome(item) ? null : widget.labelOf(item.note),
            wash: item.id == _washId,
            onTick: () => unawaited(_tasks.setDone(item, done: true)),
            onOpenNote: () => widget.onOpenNote(item.note.id),
            onKeep: () => _tasks.keep(item),
            onRemove: () => unawaited(_remove(item)),
          ),
      ],
    );
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
        item: first,
        label: labelOf(first),
        onYes: () => _tasks.doNow(first, open),
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
          if (mounted) _tasks.doNow(benchmark, _open(_tasks.read()));
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
      onNone: () => _tasks.doNow(benchmark, open),
    );
  }

  Widget _done(TaskBoard board) {
    final palette = context.palette;
    final now = _tasks.now();
    final done = board.done.where(_matches).toList();
    final days = <DateTime, List<TaskItem>>{};
    for (final item in done) {
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
            FontWeight.w700,
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final focused = focus.hasFocus;
    final shortcut = this.shortcut;
    return Container(
      key: const ValueKey('tasks-add-row'),
      height: 40,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: Color.lerp(
          palette.editorBackground,
          palette.controlBackground,
          0.5,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
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
                const SingleActivator(LogicalKeyboardKey.escape): focus.unfocus,
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
                decoration: InputDecoration.collapsed(
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
          ),
          const SizedBox(width: 10),
          if (focused)
            const ExcludeSemantics(child: Keycap('↵'))
          else if (shortcut != null)
            ExcludeSemantics(child: Keycap(shortcut)),
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
  });

  final Note? target;
  final String Function(Note note) labelOf;
  final List<Note> choices;
  final ValueChanged<String?> onChoose;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final target = this.target;
    return Tooltip(
      message: 'Add to a note',
      child: InkWell(
        key: const ValueKey('tasks-note-picker'),
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(context),
        child: Container(
          height: 28,
          constraints: const BoxConstraints(maxWidth: 200),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            border: Border.all(color: palette.controlBorder),
            borderRadius: BorderRadius.circular(8),
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
    required this.item,
    required this.label,
    required this.onOpenNote,
    required this.onNotFinished,
    required this.onDone,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback onOpenNote;
  final VoidCallback onNotFinished;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = this.label;
    return Container(
      key: const ValueKey('tasks-do-now'),
      padding: const EdgeInsets.only(top: 14, bottom: 14, right: 16),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.controlBorder),
        borderRadius: BorderRadius.circular(14),
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
                  Text(
                    item.words,
                    style: uiStyle(
                      20,
                      28,
                      FontWeight.w600,
                      palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (label != null)
                        Flexible(
                          child: NoteMark(
                            note: item.note,
                            label: label,
                            onPressed: onOpenNote,
                          ),
                        )
                      else
                        const Spacer(),
                      if (label != null) const Spacer(),
                      Tooltip(
                        message: 'Moves it to the end of the list',
                        child: TextButton.icon(
                          key: const ValueKey('tasks-not-finished'),
                          onPressed: onNotFinished,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
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
                      const SizedBox(width: 6),
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
        borderRadius: BorderRadius.circular(16),
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
          borderRadius: BorderRadius.circular(10),
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
    required this.item,
    required this.label,
    required this.onYes,
    required this.onNotYet,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback onYes;
  final VoidCallback onNotYet;

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
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const _Dot(),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.words,
                  style: uiStyle(15, 22, FontWeight.w600, palette.textPrimary),
                ),
              ),
              if (label != null) ...[
                const SizedBox(width: 10),
                NoteMark(note: item.note, label: label),
              ],
            ],
          ),
        ),
        Text(
          'Ready to do this now?',
          style: handStyle(18, 25, FontWeight.w600, palette.textPrimary),
        ),
        Row(
          children: [
            _PickButton(
              key: const ValueKey('tasks-ready-yes'),
              label: 'Yes, do it now',
              icon: KapyIcons.checkRounded,
              tonal: true,
              onPressed: onYes,
            ),
            const SizedBox(width: 8),
            _PickButton(
              key: const ValueKey('tasks-ready-not-yet'),
              label: 'Not yet, look further',
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
      borderRadius: BorderRadius.circular(10),
      hoverColor: palette.controlBackground,
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.only(left: 10, right: 8),
          child: Row(
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
                    borderRadius: BorderRadius.circular(8),
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
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: NoteMark(note: widget.item.note, label: label),
                ),
            ],
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
      borderRadius: BorderRadius.circular(4),
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
            borderRadius: BorderRadius.circular(6),
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

/// One task in the list: its mark in the gutter, its box and words, and at
/// the end what is worth knowing about it.
class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.item,
    required this.now,
    required this.label,
    required this.wash,
    required this.onTick,
    required this.onOpenNote,
    required this.onKeep,
    required this.onRemove,
  });

  final TaskItem item;
  final DateTime now;

  /// The note's name on its mark; null for a task with no note.
  final String? label;

  /// Just added: a sage wash that fades.
  final bool wash;
  final VoidCallback onTick;
  final VoidCallback onOpenNote;
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
    Widget mark;
    if (item.doNow) {
      mark = const Tooltip(message: 'Do now: your last pick', child: _Ring());
    } else if (item.dotted) {
      mark = const Tooltip(message: 'Picked to do next', child: _Dot());
    } else {
      mark = const SizedBox.shrink();
    }
    final row = SizedBox(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Row(
          children: [
            SizedBox.square(dimension: 20, child: Center(child: mark)),
            const SizedBox(width: 10),
            _Box(done: false, onPressed: widget.onTick, label: item.words),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.words,
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
                constraints: const BoxConstraints(maxWidth: 220),
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
            borderRadius: BorderRadius.circular(10),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
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
