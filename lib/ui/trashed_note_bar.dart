import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'sidebar.dart' show trashIcon;

/// The slim bar over a note in Recently deleted, whose page is read-only:
/// where the note is, and the way back.
class TrashedNoteBar extends StatelessWidget {
  const TrashedNoteBar({super.key, this.onPutBack, this.phone = false});

  /// Null for a note the reader may only view.
  final VoidCallback? onPutBack;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final size = phone ? 13.0 : 12.0;
    TextStyle style(Color color) => chromeStyle(
      size: size,
      line: 16,
      weight: AppWeight.regular,
      color: color,
    );
    final onPutBack = this.onPutBack;
    return ColoredBox(
      key: const ValueKey('trashed-note-bar'),
      color: palette.cardBackground,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            KapyIcon(trashIcon, size: 14, color: palette.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'In Recently deleted',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style(palette.textSecondary),
              ),
            ),
            if (onPutBack != null) ...[
              Text(' · ', style: style(palette.textQuiet)),
              Semantics(
                button: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: const ValueKey('trashed-note-put-back'),
                    onTap: onPutBack,
                    behavior: HitTestBehavior.opaque,
                    child: Text('Put back', style: style(palette.accentText)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
