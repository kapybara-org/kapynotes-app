import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../sync/presence.dart';
import '../sync/spaces.dart';
import 'compact_icon_button.dart';
import 'context_menu.dart';
import 'member_avatars.dart';
import 'sidebar_timestamp.dart';

/// A note's header on a phone, as M07 and M09 draw it: ⌂ Home, then the
/// note's day, Kapy AI and More. Under them, while the day has it open, the
/// note's week and the line that opens the day's tasks, then on a page that
/// shows a day's notes as tabs, those, then a hairline.
class PhoneNoteHeader extends StatelessWidget {
  const PhoneNoteHeader({
    super.key,
    required this.onHome,
    required this.menu,
    required this.onMenu,
    this.day,
    this.today,
    this.weekOpen = true,
    this.onWeekToggled,
    this.week,
    this.tasks = 0,
    this.onTasks,
    this.tabs,
    this.members = const [],
    this.present = const [],
    this.currentUserId = '',
    this.onMembers,
    this.assistant,
    this.typing = false,
  });

  final VoidCallback onHome;

  /// Everything the note offers, in its groups, under More.
  final KapyMenu menu;
  final void Function(String value, Offset at) onMenu;

  /// The note's day, which the day button shows, and today, which turns its
  /// figure sage. Null on a page with no days, such as Shared's, which has no week.
  final DateTime? day;
  final DateTime? today;

  /// Whether the week is open under the header. The day button turns it.
  final bool weekOpen;
  final VoidCallback? onWeekToggled;
  final Widget? week;

  /// How many tasks the line under the week counts, and what opens them.
  /// The line shows only while there are some.
  final int tasks;
  final VoidCallback? onTasks;

  /// A day's notes as tabs (A1), last in the header, the week or not. Under
  /// an open week they take the place of the room that ends it.
  final Widget? tabs;

  /// Who else has the note, at the left of the day button.
  final List<SpaceMember> members;
  final List<Collaborator> present;
  final String currentUserId;
  final VoidCallback? onMembers;

  /// Kapy AI's button, between the day and More. Null where it is off.
  final Widget? assistant;

  /// While a note with words in it is being typed in (M08) the row of
  /// buttons steps back, and the week and the tasks line stay as they are.
  final bool typing;

  /// The row of buttons, and the line that opens the tasks.
  static const double rowHeight = 52;
  static const double tasksHeight = 44;

  /// "2 tasks on Fri 21" for a day still to come, whose waiting tasks it
  /// counts, or "6 tasks today" for today and any day before it, which count
  /// today's list.
  static String tasksLine(int count, DateTime day, DateTime today) {
    final tasks = count == 1 ? '1 task' : '$count tasks';
    return day.isAfter(today)
        ? '$tasks on ${SidebarTimestamp.weekdayAndDay(day)}'
        : '$tasks today';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final day = this.day;
    final today = this.today;
    final week = this.week;
    final onTasks = this.onTasks;
    final open = weekOpen && week != null;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: DecoratedBox(
        key: const ValueKey('phone-note-header'),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.railBorder)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedOpacity(
              key: const ValueKey('phone-note-header-row'),
              opacity: typing ? 0.5 : 1,
              duration: const Duration(milliseconds: 150),
              child: SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 6),
                  child: Row(
                    children: [
                      _HomeButton(onPressed: onHome),
                      const Spacer(),
                      if (members.isNotEmpty)
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: MemberAvatars(
                              members: members,
                              present: present,
                              currentUserId: currentUserId,
                              onPressed: onMembers,
                            ),
                          ),
                        ),
                      if (day != null && today != null)
                        _DayButton(
                          day: day,
                          today: day == today,
                          open: open,
                          onPressed: onWeekToggled,
                        ),
                      ?assistant,
                      Builder(
                        builder: (button) => CompactIconButton(
                          key: const ValueKey('page-more'),
                          tooltip: 'More',
                          extent: AppControlMetrics.iconButtonExtent,
                          radius: 10,
                          onPressed: menu.groups.every((group) => group.isEmpty)
                              ? null
                              : () => _showMenu(button),
                          icon: KapyIcon(
                            KapyIcons.moreVerticalRounded,
                            size: AppControlMetrics.iconAction,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (open) ...[
              week,
              if (tasks > 0 && onTasks != null && day != null && today != null)
                _TasksLine(
                  label: tasksLine(tasks, day, today),
                  onPressed: onTasks,
                )
              else if (tabs == null)
                const SizedBox(height: 8),
            ],
            ?tabs,
          ],
        ),
      ),
    );
  }

  /// Opens under More, its right edge on the button's, in M09's groups.
  void _showMenu(BuildContext button) {
    final box = button.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset(box.size.width, box.size.height + 4));
    unawaited(
      showKapyContextMenu<String>(
        context: button,
        globalPosition: at,
        items: kapyMenuItems(
          menu,
          key: (value) => 'page-more-$value',
          height: 44,
        ),
      ).then((choice) {
        if (choice != null) onMenu(choice, at);
      }),
    );
  }
}

/// ⌂ Home: back to the notes, whichever list the note was opened from.
class _HomeButton extends StatelessWidget {
  const _HomeButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      label: 'Home',
      excludeSemantics: true,
      child: TextButton(
        key: const ValueKey('page-home'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.only(left: 8, right: 10),
          foregroundColor: palette.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KapyIcon(
              KapyIcons.homeOutlined,
              size: AppControlMetrics.iconAction,
              color: palette.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              'Home',
              maxLines: 1,
              style: chromeStyle(
                size: AppTypeScale.control,
                line: 20,
                weight: AppWeight.button,
                color: palette.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The note's date in a small chip on the control fill, its figure sage on
/// today's note, inside a 44 pt target: it opens and closes the week.
class _DayButton extends StatelessWidget {
  const _DayButton({
    required this.day,
    required this.today,
    required this.open,
    required this.onPressed,
  });

  final DateTime day;
  final bool today;
  final bool open;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      toggled: open,
      label: open ? 'Hide the week' : 'Show the week',
      excludeSemantics: true,
      child: InkResponse(
        key: const ValueKey('page-day'),
        onTap: onPressed,
        radius: 22,
        highlightShape: BoxShape.rectangle,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: Container(
              key: const ValueKey('page-day-chip'),
              constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: palette.controlBackground,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                textAlign: TextAlign.center,
                '${day.day}',
                maxLines: 1,
                style: chromeStyle(
                  size: AppTypeScale.control,
                  line: 20,
                  weight: AppWeight.rowTitle,
                  color: today ? palette.accentText : palette.textPrimary,
                  tabular: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "2 tasks on Fri 21 ›", which opens the tasks sheet.
class _TasksLine extends StatelessWidget {
  const _TasksLine({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      key: const ValueKey('page-tasks-line'),
      onTap: onPressed,
      child: Container(
        height: PhoneNoteHeader.tasksHeight,
        padding: const EdgeInsets.only(left: 20, right: 18),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chromeStyle(
                  size: AppTypeScale.control,
                  line: 20,
                  weight: AppWeight.body,
                  color: palette.textSecondary,
                ),
              ),
            ),
            KapyIcon(
              KapyIcons.chevronRightRounded,
              size: 16,
              color: palette.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
