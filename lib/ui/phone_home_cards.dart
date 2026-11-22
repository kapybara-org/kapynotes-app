import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/note.dart';

/// Home's cards over a phone's list of days: Pinned, and Shared while there
/// is sharing to open. Each counts its notes, names the first of them, and
/// opens its own list.
class PhoneHomeCards extends StatelessWidget {
  const PhoneHomeCards({
    super.key,
    required this.pinned,
    this.onOpenPinned,
    this.shared,
    this.invitations = 0,
    this.onOpenShared,
  });

  final List<Note> pinned;

  /// Null while nothing is pinned, when there is no list to open.
  final VoidCallback? onOpenPinned;

  /// Every shared note, newest first. Null leaves the card out, for a phone
  /// with no account to share from.
  final List<Note>? shared;

  /// Invitations waiting under Shared, counted on its icon.
  final int invitations;
  final VoidCallback? onOpenShared;

  @override
  Widget build(BuildContext context) {
    final shared = this.shared;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _HomeCard(
              key: const ValueKey('home-pinned-card'),
              icon: KapyIcons.pinOutlined,
              name: 'Pinned',
              notes: pinned,
              empty: 'Nothing pinned yet',
              onPressed: onOpenPinned,
            ),
          ),
          if (shared != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _HomeCard(
                key: const ValueKey('home-shared-card'),
                icon: KapyIcons.groupOutlined,
                name: 'Shared',
                notes: shared,
                empty: 'Nothing shared yet',
                invitations: invitations,
                onPressed: onOpenShared,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The tiles over a phone's folder tree (M02): Drawings, which counts the
/// drawings and names the newest with its day. It takes half the row, the
/// other half being Upcoming's when that comes.
class PhoneFolderTiles extends StatelessWidget {
  const PhoneFolderTiles({
    super.key,
    required this.drawings,
    required this.newest,
    required this.onOpenDrawings,
  });

  final List<Note> drawings;

  /// The newest drawing's title and day, such as "Deck flow · Today".
  final String? newest;
  final VoidCallback onOpenDrawings;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _HomeCard(
            key: const ValueKey('folders-drawings-tile'),
            icon: KapyIcons.penRounded,
            name: 'Drawings',
            notes: drawings,
            empty: 'No drawings yet',
            detail: newest,
            oneLine: true,
            onPressed: onOpenDrawings,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(child: SizedBox()),
      ],
    ),
  );
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    super.key,
    required this.icon,
    required this.name,
    required this.notes,
    required this.empty,
    required this.onPressed,
    this.invitations = 0,
    this.detail,
    this.oneLine = false,
  });

  final KapyIconData icon;
  final String name;
  final List<Note> notes;

  /// The lines under the name while there are no notes to name.
  final String empty;
  final VoidCallback? onPressed;
  final int invitations;

  /// One line under the name in place of the notes' titles, as a folder
  /// tile has, or [empty] in its place while it is null.
  final String? detail;
  final bool oneLine;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final count = notes.length;
    final waiting = switch (invitations) {
      0 => '',
      1 => ', 1 invitation waiting',
      _ => ', $invitations invitations waiting',
    };
    return Semantics(
      container: true,
      button: onPressed != null,
      label: '$name, $count ${count == 1 ? 'note' : 'notes'}$waiting',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: palette.fillRest,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: palette.selectedBackground,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: KapyIcon(
                            icon,
                            size: 18,
                            color: palette.textPrimary,
                          ),
                        ),
                        if (invitations > 0)
                          Positioned(
                            top: -5,
                            right: -5,
                            child: Container(
                              key: const ValueKey('home-shared-invitations'),
                              height: 16,
                              constraints: const BoxConstraints(minWidth: 16),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: palette.clay,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                invitations > 99 ? '99+' : '$invitations',
                                textScaler: TextScaler.noScaling,
                                style: chromeStyle(
                                  size: 11,
                                  line: 12,
                                  weight: 600,
                                  color: palette.paperColor,
                                  tabular: true,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '$count',
                      style: chromeStyle(
                        size: 13,
                        line: 16,
                        weight: 400,
                        color: palette.textTertiary,
                        tabular: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: chromeStyle(
                    size: 16,
                    line: 22,
                    weight: 500,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                if (oneLine)
                  Text(
                    detail ?? empty,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: chromeStyle(
                      size: 13,
                      line: 16,
                      weight: 400,
                      color: palette.textMuted,
                    ),
                  )
                else
                  // Two lines' room whatever fills it, so the cards keep one
                  // height as notes come and go.
                  SizedBox(
                    height:
                        MediaQuery.textScalerOf(context).scale(13) * 36 / 13,
                    child: Text(
                      notes.isEmpty
                          ? empty
                          : [
                              for (final note in notes.take(8)) note.title,
                            ].join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: chromeStyle(
                        size: 13,
                        line: 18,
                        weight: 400,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
