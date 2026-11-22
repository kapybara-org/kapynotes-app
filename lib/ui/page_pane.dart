import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The page the open note is written on: flush with the window, as D01 and
/// the crisp pass have it, with one hairline at its left edge while the notes
/// list sits beside it. Beside the rail, the rail's own edge is the line.
///
/// In glass mode the pane has no fill: everything on it paints its own
/// translucent paper, the page toolbar included.
class PagePane extends StatelessWidget {
  const PagePane({super.key, required this.divided, required this.child});

  /// Whether the notes list sits beside the page.
  final bool divided;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('page-pane'),
      color: palette.isGlass ? null : palette.paperColor,
      foregroundDecoration: divided
          ? BoxDecoration(
              border: Border(left: BorderSide(color: palette.pageBorder)),
            )
          : null,
      child: child,
    );
  }
}
