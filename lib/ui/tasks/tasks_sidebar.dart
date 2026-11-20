import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/note.dart';
import '../../data/shortcut_prefs.dart';
import '../../data/task_board.dart';
import '../sidebar.dart';
import 'task_marks.dart';

/// Forster's own instructions for Final Version Perfected.
final Uri fvpInstructions = Uri.parse(
  'http://markforster.squarespace.com/blog/2021/11/16/'
  'the-final-version-perfected-fvp-instructions-reposted.html',
);

/// The list beside Tasks: a filter, not a second list. All tasks, Done, then
/// each note with open tasks and how many, with No note last; and at its
/// foot, where the method comes from.
class TasksSidebar extends StatelessWidget {
  const TasksSidebar({
    super.key,
    required this.board,
    required this.filter,
    required this.onFilter,
    required this.labelOf,
    required this.windowBar,
    required this.onSearch,
    this.searchShortcut,
    this.searchPlaceholder = 'Search',
  });

  final TaskBoard board;
  final TaskFilter filter;
  final ValueChanged<TaskFilter> onFilter;
  final String Function(Note note) labelOf;
  final Widget windowBar;

  /// Opens the ⌘K menu, from the field over the filters.
  final VoidCallback onSearch;
  final ShortcutBinding? searchShortcut;
  final String searchPlaceholder;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final counts = <String, int>{};
    final notes = <String, Note>{};
    for (final item in board.open) {
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                children: [
                  _FilterRow(
                    key: const ValueKey('tasks-filter-all'),
                    leading: (ink) => KapyIcon(
                      KapyIcons.checklistRounded,
                      size: 15,
                      strokeWidth: 1.8,
                      color: ink,
                    ),
                    label: 'All tasks',
                    count: board.open.length,
                    selected: filter == const TaskFilter.all(),
                    onPressed: () => onFilter(const TaskFilter.all()),
                  ),
                  const SizedBox(height: 2),
                  _FilterRow(
                    key: const ValueKey('tasks-filter-done'),
                    leading: (ink) => KapyIcon(
                      KapyIcons.checkRounded,
                      size: 15,
                      strokeWidth: 1.8,
                      color: ink,
                    ),
                    label: 'Done',
                    count: board.done.length,
                    selected: filter.done,
                    onPressed: () => onFilter(const TaskFilter.done()),
                  ),
                  if (ordered.isNotEmpty || homeCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                      child: Text(
                        'From notes',
                        style: handStyle(
                          14,
                          20,
                          FontWeight.w600,
                          palette.textSubheading,
                        ),
                      ),
                    ),
                  for (final id in ordered) ...[
                    _FilterRow(
                      key: ValueKey('tasks-filter-$id'),
                      leading: (_) => NoteSwatch(note: notes[id], size: 14),
                      label: labelOf(notes[id]!),
                      hand: true,
                      count: counts[id]!,
                      selected: filter.noteId == id,
                      onPressed: () => onFilter(TaskFilter.note(id)),
                    ),
                    const SizedBox(height: 2),
                  ],
                  if (home != null && homeCount > 0)
                    _FilterRow(
                      key: const ValueKey('tasks-filter-no-note'),
                      leading: (_) => const NoteSwatch(note: null, size: 14),
                      label: 'No note',
                      count: homeCount,
                      selected: filter.noteId == home.id,
                      onPressed: () => onFilter(TaskFilter.note(home.id)),
                    ),
                ],
              ),
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
    required this.leading,
    required this.label,
    required this.count,
    required this.selected,
    required this.onPressed,
    this.hand = false,
  });

  /// Drawn in the ink the row gives it: sage when selected.
  final Widget Function(Color ink) leading;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onPressed;

  /// A note's name, in the hand notes are titled in.
  final bool hand;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ink = selected ? palette.textPrimary : palette.textSubheading;
    final weight = selected ? FontWeight.w700 : FontWeight.w500;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadii.control),
        hoverColor: palette.hover,
        child: Ink(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? palette.controlBackground : null,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: Center(
                  child: leading(
                    selected ? palette.tonalForeground : palette.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: hand
                      ? handStyle(13.5, 18, weight, ink)
                      : uiStyle(13.5, 18, weight, ink),
                ),
              ),
              Text(
                '$count',
                style: uiStyle(
                  12,
                  16,
                  FontWeight.w600,
                  selected ? palette.tonalForeground : palette.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Based on FVP by Mark Forster": hovering or focusing it opens three lines
/// on the method and the way to Forster's instructions, so there is no
/// first-run card to dismiss.
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
            child: const _MethodCard(),
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
              padding: const EdgeInsets.only(left: 24, right: 24, bottom: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Based on FVP by Mark Forster',
                    style: uiStyle(
                      12.5,
                      16,
                      FontWeight.w500,
                      open ? palette.textSecondary : palette.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  KapyIcon(
                    KapyIcons.infoOutlined,
                    size: 14,
                    strokeWidth: 1.8,
                    color: open ? palette.textSubheading : palette.textTertiary,
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

class _MethodCard extends StatelessWidget {
  const _MethodCard();

  static const _lines = [
    'One list, always today. New tasks go to the end.',
    'To pick, ask “What do I want to do more than this?” Dots mark the '
        'tasks you picked; the last one is Do now.',
    "Or click a task's dot yourself: once picks it, again makes it Do now.",
    "Anything you don't finish goes back to the end.",
  ];

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const ValueKey('tasks-method-card'),
        width: 328,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: palette.controlBackground,
          border: Border.all(color: palette.separator),
          borderRadius: BorderRadius.circular(AppRadii.surface),
          boxShadow: [
            BoxShadow(
              color: palette.shadow.withAlpha(0x80),
              offset: const Offset(0, 12),
              blurRadius: 28,
              spreadRadius: -14,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Final Version Perfected',
              style: handStyle(14, 20, FontWeight.w600, palette.textPrimary),
            ),
            const SizedBox(height: 8),
            for (final (index, line) in _lines.indexed) ...[
              if (index > 0) const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      line,
                      style: uiStyle(
                        12.5,
                        19,
                        FontWeight.w500,
                        palette.textSubheading,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                InkWell(
                  key: const ValueKey('tasks-read-fvp'),
                  onTap: () => unawaited(
                    launchUrl(
                      fvpInstructions,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Read about FVP',
                        style: uiStyle(
                          12.5,
                          16,
                          FontWeight.w600,
                          palette.accentText,
                        ),
                      ),
                      const SizedBox(width: 4),
                      KapyIcon(
                        KapyIcons.openExternalRounded,
                        size: 13,
                        strokeWidth: 1.9,
                        color: palette.accentText,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  'The successor to Autofocus',
                  style: uiStyle(
                    11.5,
                    16,
                    FontWeight.w500,
                    palette.textTertiary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
