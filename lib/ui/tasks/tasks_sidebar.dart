import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/note.dart';
import '../../data/shortcut_prefs.dart';
import '../../data/task_board.dart';
import '../sidebar.dart';
import 'task_choice_cards.dart';
import 'task_marks.dart';

/// Forster's own instructions for Final Version Perfected.
final Uri fvpInstructions = Uri.parse(
  'http://markforster.squarespace.com/blog/2021/11/16/'
  'the-final-version-perfected-fvp-instructions-reposted.html',
);

/// One way to narrow Tasks: Today, Done, or a note with tasks on today's list.
class TaskFilterChoice {
  const TaskFilterChoice(
    this.filter,
    this.label,
    this.count, {
    this.note,
    this.noNote = false,
  });

  final TaskFilter filter;
  final String label;
  final int count;

  /// The note whose swatch marks it; null for Today, Done and No note.
  final Note? note;

  /// The tasks with no note of their own, marked by a dashed swatch.
  final bool noNote;

  /// Names the choice's row, in the sidebar and in a phone's filter.
  String get key => switch (filter) {
    _ when noNote => 'no-note',
    TaskFilter(:final noteId?) => noteId,
    TaskFilter(done: true) => 'done',
    _ => 'all',
  };
}

/// What Tasks can be narrowed to, in the order the sidebar and a phone's
/// filter list them: Today and Done, then each note with tasks on [today]'s
/// list, the most first, with No note last. A note whose tasks all wait for
/// a later day isn't listed.
List<TaskFilterChoice> taskFilterChoices({
  required TaskBoard board,
  required List<TaskItem> today,
  required String Function(Note note) labelOf,
}) {
  final counts = <String, int>{};
  final notes = <String, Note>{};
  for (final item in today) {
    counts.update(item.note.id, (n) => n + 1, ifAbsent: () => 1);
    notes[item.note.id] = item.note;
  }
  final home = board.home;
  final homeCount = home == null ? 0 : counts.remove(home.id) ?? 0;
  final ordered = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0
          ? byCount
          : labelOf(
              notes[a]!,
            ).toLowerCase().compareTo(labelOf(notes[b]!).toLowerCase());
    });
  return [
    TaskFilterChoice(const TaskFilter.all(), 'Today', today.length),
    TaskFilterChoice(const TaskFilter.done(), 'Done', board.done.length),
    for (final id in ordered)
      TaskFilterChoice(
        TaskFilter.note(id),
        labelOf(notes[id]!),
        counts[id]!,
        note: notes[id],
      ),
    if (home != null && homeCount > 0)
      TaskFilterChoice(
        TaskFilter.note(home.id),
        'No note',
        homeCount,
        noNote: true,
      ),
  ];
}

/// The mark before a filter's name: Today's list, Done's tick, or the note's
/// swatch, in [ink].
Widget taskFilterMark(TaskFilterChoice choice, Color ink, {double size = 16}) =>
    switch (choice) {
      TaskFilterChoice(noNote: true) => const NoteSwatch(note: null, size: 8),
      TaskFilterChoice(:final note?) => NoteSwatch(note: note, size: 8),
      TaskFilterChoice(filter: TaskFilter(done: true)) => KapyIcon(
        KapyIcons.checkRounded,
        size: size,
        color: ink,
      ),
      _ => KapyIcon(KapyIcons.tasksOutlined, size: size, color: ink),
    };

/// The list beside Tasks: a filter, not a second list. Today, Done, then
/// each note with tasks on today's list and how many, with No note last; and
/// at its foot, where the method comes from.
class TasksSidebar extends StatelessWidget {
  const TasksSidebar({
    super.key,
    required this.board,
    required this.today,
    required this.filter,
    required this.onFilter,
    required this.labelOf,
    required this.windowBar,
    required this.onSearch,
    this.searchShortcut,
    this.searchPlaceholder = 'Search',
    this.onGotIt,
  });

  final TaskBoard board;

  /// Today's open tasks, without those whose note waits for a later day.
  final List<TaskItem> today;
  final TaskFilter filter;
  final ValueChanged<TaskFilter> onFilter;
  final String Function(Note note) labelOf;
  final Widget windowBar;

  /// Opens the ⌘K menu, from the field over the filters.
  final VoidCallback onSearch;
  final ShortcutBinding? searchShortcut;
  final String searchPlaceholder;

  /// While set, "How Tasks works" sits at the foot until Got it, which
  /// calls this.
  final VoidCallback? onGotIt;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final choices = taskFilterChoices(
      board: board,
      today: today,
      labelOf: labelOf,
    );
    return ColoredBox(
      color: palette.sidebarColor,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            windowBar,
            SidebarSearchField(
              onSearch: onSearch,
              shortcut: searchShortcut,
              placeholder: searchPlaceholder,
            ),
            Expanded(
              // The rows' fill and hover are ink, which lands on the nearest
              // Material: this one, over the sidebar's colour, not the
              // window's under it.
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                  children: [
                    for (final (index, choice) in choices.indexed) ...[
                      if (index == 2)
                        Container(
                          height: 36,
                          alignment: Alignment.bottomLeft,
                          padding: const EdgeInsets.only(left: 10, bottom: 6),
                          child: Text(
                            'From notes',
                            style: taskText(12, 16, palette.textTertiary, 520),
                          ),
                        ),
                      _FilterRow(
                        key: ValueKey('tasks-filter-${choice.key}'),
                        choice: choice,
                        selected: filter == choice.filter,
                        onPressed: () => onFilter(choice.filter),
                      ),
                      const SizedBox(height: 2),
                    ],
                  ],
                ),
              ),
            ),
            if (onGotIt case final onGotIt?)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: HowTasksWorksCard(onGotIt: onGotIt),
              ),
            const _MethodLine(),
          ],
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    super.key,
    required this.choice,
    required this.selected,
    required this.onPressed,
  });

  final TaskFilterChoice choice;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        hoverColor: palette.hover,
        child: Ink(
          height: 32,
          padding: const EdgeInsets.only(left: 10, right: 14),
          decoration: BoxDecoration(
            color: selected ? palette.selectedBackground : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            spacing: 10,
            children: [
              SizedBox.square(
                dimension: 16,
                child: Center(
                  child: taskFilterMark(
                    choice,
                    selected ? palette.textPrimary : palette.textTertiary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  choice.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: taskText(
                    13,
                    18,
                    palette.textPrimary,
                    selected ? 460 : 400,
                  ),
                ),
              ),
              Text(
                '${choice.count}',
                style: metaStyle(
                  12,
                  16,
                  selected ? palette.textSecondary : palette.textTertiary,
                  tabular: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Based on FVP by Mark Forster": hovering or focusing it opens "How Tasks
/// works", so the steps stay in reach once its first card is put away.
class _MethodLine extends StatefulWidget {
  const _MethodLine();

  @override
  State<_MethodLine> createState() => _MethodLineState();
}

class _MethodLineState extends State<_MethodLine> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  bool _overLine = false;
  bool _overCard = false;
  bool _focused = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _update() {
    _hide?.cancel();
    if (_overLine || _overCard || _focused) {
      if (!_portal.isShowing) _portal.show();
      setState(() {});
      return;
    }
    _hide = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _portal.isShowing) {
        _portal.hide();
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final open = _portal.isShowing;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(-12, -4),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: MouseRegion(
            onEnter: (_) {
              _overCard = true;
              _update();
            },
            onExit: (_) {
              _overCard = false;
              _update();
            },
            child: const HowTasksWorksCard(floating: true),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: Focus(
          onFocusChange: (focused) {
            _focused = focused;
            _update();
          },
          child: MouseRegion(
            key: const ValueKey('tasks-method-line'),
            onEnter: (_) {
              _overLine = true;
              _update();
            },
            onExit: (_) {
              _overLine = false;
              _update();
            },
            child: Container(
              height: 44,
              padding: const EdgeInsets.only(left: 20, right: 20, bottom: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Based on FVP by Mark Forster',
                    style: taskText(
                      12,
                      16,
                      open ? palette.textPrimary : palette.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  KapyIcon(
                    KapyIcons.infoOutlined,
                    size: 14,
                    color: open ? palette.textSecondary : palette.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "How Tasks works": the method in four plain lines and the way to
/// Forster's own steps. On a first visit it sits at the sidebar's foot with
/// Got it; afterwards it opens from the credit.
class HowTasksWorksCard extends StatelessWidget {
  const HowTasksWorksCard({super.key, this.onGotIt, this.floating = false});

  final VoidCallback? onGotIt;

  /// Opened from the credit, over the sidebar, with a shadow.
  final bool floating;

  static const _lines = [
    'Today has one list. New tasks join the end.',
    'To choose, Tasks shows two at a time. Pick the more important one with '
        '← or →, and the next one comes in.',
    'Your last pick becomes Do now, and earlier picks wait in Up next. Not '
        'finished sends a task to the end of the list.',
    'A task left alone for two weeks asks if you still want it.',
  ];

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final onGotIt = this.onGotIt;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: ValueKey(floating ? 'tasks-method-card' : 'tasks-how-it-works'),
        width: floating ? 316 : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: ink.raised,
          border: Border.all(color: ink.edge),
          borderRadius: BorderRadius.circular(12),
          boxShadow: floating
              ? [
                  BoxShadow(
                    color: context.palette.shadow.withAlpha(0x80),
                    offset: const Offset(0, 12),
                    blurRadius: 28,
                    spreadRadius: -14,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Semantics(
                header: true,
                child: Text(
                  'How Tasks works',
                  style: taskText(13, 18, ink.text, 500),
                ),
              ),
            ),
            for (final line in _lines)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(top: 7),
                    decoration: BoxDecoration(
                      color: ink.sage,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(line, style: taskText(12, 18, ink.secondary)),
                  ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: InkWell(
                        key: const ValueKey('tasks-read-fvp'),
                        onTap: () => unawaited(
                          launchUrl(
                            fvpInstructions,
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                        child: Text(
                          'Read Mark Forster’s own steps',
                          style: taskText(12, 16, ink.sage, 500),
                        ),
                      ),
                    ),
                  ),
                  if (onGotIt != null)
                    TaskButton(
                      key: const ValueKey('tasks-got-it'),
                      semantics: 'Got it',
                      onPressed: onGotIt,
                      fill: ink.chip,
                      height: 24,
                      radius: 5,
                      children: [
                        Text('Got it', style: taskText(12, 16, ink.text, 460)),
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
