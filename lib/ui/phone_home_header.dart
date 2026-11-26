import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/writing_streak.dart';
import '../sync/auth_api.dart';
import 'spaces_rail.dart' show AccountAvatar, StreakMark;
import 'tasks/task_marks.dart';

/// Home's header on a phone: the Notes and Tasks titles, the one on screen
/// bright with its count, then the writing streak and the avatar that opens
/// Settings.
///
/// Notes keeps its count's room while Tasks is on screen, so Tasks sits 16
/// after the count on both pages and stays put when you swipe between them.
class PhoneHomeHeader extends StatelessWidget {
  const PhoneHomeHeader({
    super.key,
    required this.tasks,
    required this.notesCount,
    this.tasksCount = 0,
    required this.onNotes,
    this.onTasks,
    this.streak,
    this.user,
    required this.onSettings,
  });

  /// Whether Tasks is on screen rather than Notes.
  final bool tasks;

  /// How many notes Notes holds, and how many open tasks Tasks holds.
  final int notesCount;
  final int tasksCount;
  final VoidCallback onNotes;

  /// Null leaves Tasks out, for a phone without them.
  final VoidCallback? onTasks;

  /// The writing streak, shown while it runs.
  final WritingStreak? streak;

  /// Who is signed in, for the avatar's initial. Null while nobody is.
  final AccountUser? user;
  final VoidCallback onSettings;

  /// How far S's 44 pt target reaches past its 32 pt circle on each side,
  /// into the room around it, so the circle keeps its place.
  static const double _reach = 6;

  @override
  Widget build(BuildContext context) {
    final onTasks = this.onTasks;
    final streak = this.streak;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        height: 48,
        padding: const EdgeInsets.only(left: 20, right: 20 - _reach),
        child: Row(
          spacing: 16,
          children: [
            _Title(
              key: const ValueKey('home-title-notes'),
              label: 'Notes',
              count: notesCount,
              selected: !tasks,
              onPressed: onNotes,
            ),
            if (onTasks != null)
              _Title(
                key: const ValueKey('home-title-tasks'),
                label: 'Tasks',
                count: tasksCount,
                selected: tasks,
                onPressed: onTasks,
              ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 12 - _reach,
                children: [
                  if (streak != null && streak.days > 0)
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: StreakMark(
                          key: const ValueKey('phone-streak'),
                          streak: streak,
                          inline: true,
                        ),
                      ),
                    ),
                  AccountAvatar(
                    key: const ValueKey('phone-account'),
                    label: 'Settings',
                    target: 32 + 2 * _reach,
                    user: user,
                    onPressed: onSettings,
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

/// One of Home's titles. The one on screen is bright with its count; the
/// other waits a grey quieter, keeping its count's room unseen.
class _Title extends StatelessWidget {
  const _Title({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      label: selected ? '$label, $count' : label,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            spacing: 6,
            children: [
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: uiStyle(
                  AppTypeScale.spaceTitle,
                  32,
                  FontWeight.w600,
                  selected ? palette.textHeading : palette.textQuiet,
                ),
              ),
              Visibility.maintain(
                visible: selected,
                child: Text(
                  '$count',
                  maxLines: 1,
                  softWrap: false,
                  style: uiStyle(
                    13,
                    16,
                    FontWeight.w400,
                    palette.textQuiet,
                    tabular: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Home on a phone, which a sideways swipe turns between Notes and Tasks.
/// A row's own swipe, deeper in the tree, wins the gesture first, except
/// from the left edge with [backFromEdge] on, or on a page iOS's own back
/// swipe can leave.
class PhoneHomeSwipe extends StatefulWidget {
  const PhoneHomeSwipe({
    super.key,
    required this.onTurn,
    this.backFromEdge = false,
    required this.child,
  });

  /// Called with true for a swipe left, to Tasks, and false for a swipe
  /// right, to Notes or back. Null where a swipe does nothing.
  final ValueChanged<bool>? onTurn;

  /// Whether a swipe from the left edge goes back ahead of a row's own, as
  /// iOS's back swipe does where the page has none of its own.
  final bool backFromEdge;
  final Widget child;

  /// How far, or how fast, a swipe has to go to turn the page.
  static const double distance = 64;
  static const double speed = 600;

  /// How far in from the left a swipe starts at the edge, ahead of a row's.
  static const double edge = 20;

  @override
  State<PhoneHomeSwipe> createState() => _PhoneHomeSwipeState();
}

class _PhoneHomeSwipeState extends State<PhoneHomeSwipe> {
  double _dx = 0;

  void _end(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dx = velocity.abs() >= PhoneHomeSwipe.speed ? velocity : _dx;
    if (dx.abs() < PhoneHomeSwipe.distance) return;
    widget.onTurn?.call(dx < 0);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.onTurn != null;
    GestureDetector swipe({HitTestBehavior? behavior, required Widget child}) =>
        GestureDetector(
          behavior: behavior,
          onHorizontalDragStart: on ? (_) => _dx = 0 : null,
          onHorizontalDragUpdate: on
              ? (details) => _dx += details.primaryDelta ?? 0
              : null,
          onHorizontalDragEnd: on ? _end : null,
          child: child,
        );
    return swipe(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (on && widget.backFromEdge)
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: PhoneHomeSwipe.edge,
              child: swipe(
                behavior: HitTestBehavior.translucent,
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}
