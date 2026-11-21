import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/writing_streak.dart';
import '../sync/auth_api.dart';
import 'editor/note_header.dart' show NoteTitleUnderline;
import 'spaces_rail.dart' show AccountAvatar, StreakMark;
import 'tasks/task_marks.dart';

/// Home's header on a phone: the Notes and Tasks titles, the one on screen
/// in ink with its count and the note title's clay underline, then the
/// writing streak and the avatar that opens Settings.
class PhoneHomeHeader extends StatelessWidget {
  const PhoneHomeHeader({
    super.key,
    required this.tasks,
    required this.count,
    required this.onNotes,
    this.onTasks,
    this.streak,
    this.user,
    required this.onSettings,
  });

  /// Whether Tasks is on screen rather than Notes.
  final bool tasks;

  /// How many the title on screen holds.
  final int count;
  final VoidCallback onNotes;

  /// Null leaves Tasks out, for a phone without them.
  final VoidCallback? onTasks;

  /// The writing streak, shown while it runs.
  final WritingStreak? streak;

  /// Who is signed in, for the avatar's initial. Null while nobody is.
  final AccountUser? user;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final onTasks = this.onTasks;
    final streak = this.streak;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          spacing: 12,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 100),
              child: _Title(
                key: const ValueKey('home-title-notes'),
                label: 'Notes',
                count: tasks ? null : count,
                onPressed: onNotes,
              ),
            ),
            if (onTasks != null)
              _Title(
                key: const ValueKey('home-title-tasks'),
                label: 'Tasks',
                count: tasks ? count : null,
                onPressed: onTasks,
              ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: streak == null || streak.days == 0
                    ? null
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        child: StreakMark(
                          key: const ValueKey('phone-streak'),
                          streak: streak,
                          inline: true,
                        ),
                      ),
              ),
            ),
            AccountAvatar(
              key: const ValueKey('phone-account'),
              label: 'Settings',
              user: user,
              onPressed: onSettings,
            ),
          ],
        ),
      ),
    );
  }
}

/// One of Home's titles. [count] is set on the one on screen, which is in
/// ink and underlined; the other waits in grey.
class _Title extends StatelessWidget {
  const _Title({
    super.key,
    required this.label,
    required this.count,
    required this.onPressed,
  });

  final String label;
  final int? count;
  final VoidCallback onPressed;

  /// Paper's 40 × 4 mark: a 2 pt stroke over 38, drawn by the note title's
  /// own underline.
  static const _mark = Rect.fromLTWH(2.6, -24.6, 34.8, 26.7);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final count = this.count;
    final selected = count != null;
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 6,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: handStyle(
                      26,
                      32,
                      FontWeight.w600,
                      selected ? palette.textPrimary : palette.textTertiary,
                    ),
                  ),
                  if (selected)
                    Text(
                      '$count',
                      maxLines: 1,
                      softWrap: false,
                      style: uiStyle(
                        13,
                        16,
                        FontWeight.w400,
                        palette.textTertiary,
                        tabular: true,
                      ),
                    ),
                ],
              ),
              SizedBox(
                width: 40,
                height: 4,
                child: selected ? const NoteTitleUnderline(word: _mark) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Home on a phone, which a sideways swipe turns between Notes and Tasks.
/// A row's own swipe, deeper in the tree, wins the gesture first.
class PhoneHomeSwipe extends StatefulWidget {
  const PhoneHomeSwipe({super.key, required this.onTurn, required this.child});

  /// Called with true for a swipe left, to Tasks, and false for a swipe
  /// right, to Notes. Null away from Home, where a swipe does nothing.
  final ValueChanged<bool>? onTurn;
  final Widget child;

  /// How far, or how fast, a swipe has to go to turn the page.
  static const double distance = 64;
  static const double speed = 600;

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
    return GestureDetector(
      onHorizontalDragStart: on ? (_) => _dx = 0 : null,
      onHorizontalDragUpdate: on
          ? (details) => _dx += details.primaryDelta ?? 0
          : null,
      onHorizontalDragEnd: on ? _end : null,
      child: widget.child,
    );
  }
}
