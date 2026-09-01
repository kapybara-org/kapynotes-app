import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../core/platform.dart';

/// Marks a region as window chrome: dragging it moves the window, and
/// double-clicking zooms it.
///
/// Apply this only to inert parts of the toolbar. The underlying gesture
/// detector recognises double taps, which holds the gesture arena open for
/// the double-tap timeout — wrapping a button in it makes that button feel
/// sluggish on every single click.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!AppPlatform.isDesktop) return child;
    return DragToMoveArea(child: child);
  }
}
