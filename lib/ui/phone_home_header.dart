import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/writing_streak.dart';
import '../sync/auth_api.dart';
import 'notes_list.dart' show CountBadge;
import 'spaces_rail.dart' show AccountAvatar, StreakMark;

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

  @override
  Widget build(BuildContext context) {
    final onTasks = this.onTasks;
    final streak = this.streak;
    return PhoneTitleBar(
      // The titles shrink together, only when a narrow phone at large text
      // has no room for them beside the streak and S.
      title: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
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
          ],
        ),
      ),
      trailing: [
        if (streak != null && streak.days > 0)
          StreakMark(
            key: const ValueKey('phone-streak'),
            streak: streak,
            inline: true,
          ),
        AccountAvatar(
          key: const ValueKey('phone-account'),
          label: 'Settings',
          target: PhoneTitleBar.avatarTarget,
          user: user,
          onPressed: onSettings,
        ),
      ],
    );
  }
}

/// The frame every phone tab's header is drawn in, Home's and the lists'
/// alike (KAP-462): 48 tall under the status bar, text scaled no further than
/// 1.3×, the title from the 20 pt inset on Home's line, and what ends the row,
/// S last, ending at it. Switching between Notes, Folders and Kapy AI changes
/// the words in it and moves nothing.
class PhoneTitleBar extends StatelessWidget {
  const PhoneTitleBar({
    super.key,
    this.leading,
    required this.title,
    this.trailing = const [],
  });

  /// Before the title, such as a page's back arrow, from a 6 pt inset.
  final Widget? leading;
  final Widget title;
  final List<Widget> trailing;

  /// How far S's 44 pt target reaches past its 32 pt circle on each side,
  /// into the room around it, so the circle keeps its place.
  static const double _reach = 6;

  /// S's tap target, the same on every tab.
  static const double avatarTarget = 32 + 2 * _reach;

  @override
  Widget build(BuildContext context) {
    final leading = this.leading;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        height: 48,
        padding: EdgeInsets.only(
          left: leading == null ? 20 : 6,
          right: trailing.isEmpty ? 20 : 20 - _reach,
        ),
        child: Row(
          children: [
            ?leading,
            Expanded(child: title),
            if (trailing.isNotEmpty) ...[
              const SizedBox(width: 16),
              Row(spacing: 12 - _reach, children: trailing),
            ],
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
                style: handTitle(
                  size: 30,
                  line: 36,
                  color: selected ? palette.textHeading : palette.textQuiet,
                ),
              ),
              Visibility.maintain(
                visible: selected,
                child: CountBadge(count, phone: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
