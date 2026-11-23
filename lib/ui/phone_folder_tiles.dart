import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/note.dart';

/// The tiles over a phone's folder tree (M02): Drawings, which counts the
/// drawings and names the newest with its day, and Shared, which counts the
/// shared notes, names the latest with its day and marks the invitations
/// waiting there.
class PhoneFolderTiles extends StatelessWidget {
  const PhoneFolderTiles({
    super.key,
    required this.drawings,
    required this.newest,
    required this.onOpenDrawings,
    this.shared,
    this.latest,
    this.invitations = 0,
    this.onOpenShared,
  });

  final List<Note> drawings;

  /// The newest drawing's title and day, such as "Deck flow · Today".
  final String? newest;
  final VoidCallback onOpenDrawings;

  /// Every shared note, newest first. Null leaves Shared's half empty, for a
  /// phone with no account to share from.
  final List<Note>? shared;

  /// The latest shared note's title and day, such as "Trip budget · Today".
  final String? latest;

  /// Invitations waiting under Shared, counted on its icon.
  final int invitations;
  final VoidCallback? onOpenShared;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _FolderTile(
            key: const ValueKey('folders-drawings-tile'),
            icon: KapyIcons.penRounded,
            name: 'Drawings',
            notes: drawings,
            line: newest ?? 'No drawings yet',
            onPressed: onOpenDrawings,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: switch (shared) {
            final shared? => _FolderTile(
              key: const ValueKey('folders-shared-tile'),
              icon: KapyIcons.groupOutlined,
              name: 'Shared',
              notes: shared,
              line: latest ?? 'Nothing shared yet',
              invitations: invitations,
              onPressed: onOpenShared,
            ),
            null => const SizedBox(),
          },
        ),
      ],
    ),
  );
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    super.key,
    required this.icon,
    required this.name,
    required this.notes,
    required this.line,
    required this.onPressed,
    this.invitations = 0,
  });

  final KapyIconData icon;
  final String name;
  final List<Note> notes;

  /// The one line under the name.
  final String line;
  final VoidCallback? onPressed;
  final int invitations;

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
                              key: const ValueKey('folders-shared-invitations'),
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
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: chromeStyle(
                    size: 13,
                    line: 16,
                    weight: 400,
                    color: palette.textMuted,
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
