import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/presence.dart';
import '../collaborator_colors.dart';
import '../glass_surface.dart';

/// Short enough for the footer while still naming every small collaboration.
String? typingStatusText(List<String> names) {
  final unique = <String>[];
  for (final name in names) {
    final clean = name.trim();
    if (clean.isNotEmpty && !unique.contains(clean)) unique.add(clean);
  }
  return switch (unique.length) {
    0 => null,
    1 => '${unique[0]} is typing...',
    2 => '${unique[0]} and ${unique[1]} are typing...',
    _ => '${unique[0]} and ${unique.length - 1} others are typing...',
  };
}

/// What a phone's note has to say about itself when the formatting bar has no
/// room for it: who else is typing, or why it cannot be changed.
class NoteFooter extends StatelessWidget {
  const NoteFooter({
    super.key,
    this.typing = const [],
    this.readOnly = false,
    this.readOnlyLabel = 'View only',
    this.readOnlyIcon = Icons.visibility_outlined,
    this.onReadOnlyPressed,
  });

  /// Whoever else is typing in the note, by name. Their caret's colour marks
  /// the line, so the words in the footer and the flag in the text read as
  /// the same person.
  final List<Collaborator> typing;
  final bool readOnly;

  /// What [readOnly] is called here: View only for the sharing role, or the
  /// note limit's own words. [onReadOnlyPressed], when set, explains it.
  final String readOnlyLabel;
  final IconData readOnlyIcon;
  final VoidCallback? onReadOnlyPressed;

  static const double _edgeInset = 10;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final typingText = typingStatusText([
      for (final person in typing) person.name,
    ]);
    // The bar holds the bottom edge the way the toolbar holds the top one: its
    // background runs under the home indicator or the navigation bar while the
    // words stay above them.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return SizedBox(
      height:
          AppControlMetrics.scaleBar(context, AppControlMetrics.footerHeight) +
          bottomInset,
      child: GlassSurface(
        color: palette.surfaceBackground.withMultipliedAlpha(0.94),
        border: Border(
          top: BorderSide(
            color: palette.separator,
            width: AppHairline.of(context),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset, right: _edgeInset),
          child: Align(
            alignment: Alignment.centerRight,
            child: typingText != null
                ? Semantics(
                    liveRegion: true,
                    label: typingText,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final person in typing.take(3))
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: collaboratorColor(
                                  person.userId,
                                  on: palette.brightness,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            typingText,
                            key: const ValueKey('typing-presence'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTypeScale.caption,
                              fontWeight: FontWeight.w400,
                              color: palette.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : _ReadOnlyStatus(
                    label: readOnlyLabel,
                    icon: readOnlyIcon,
                    onPressed: onReadOnlyPressed,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The quiet word in the footer while a note cannot be changed, and the way
/// to find out why when there is something to explain.
class _ReadOnlyStatus extends StatelessWidget {
  const _ReadOnlyStatus({
    required this.label,
    required this.icon,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: AppControlMetrics.iconAction,
          color: palette.textTertiary,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            key: const ValueKey('view-only-status'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: FontWeight.w500,
              color: palette.textSecondary,
            ),
          ),
        ),
      ],
    );
    final pressed = onPressed;
    if (pressed == null) return status;
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: pressed,
          child: status,
        ),
      ),
    );
  }
}
