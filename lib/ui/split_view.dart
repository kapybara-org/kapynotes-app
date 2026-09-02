import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// A two-pane layout whose divider the user can drag.
///
/// The width is owned by the caller so it can be persisted; this widget only
/// reports deltas.
class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.sidebar,
    required this.body,
    required this.sidebarWidth,
    required this.onWidthChanged,
    required this.onHide,
    required this.sidebarVisible,
    this.minSidebarWidth = 150,
    this.maxSidebarWidth = 420,
  });

  final Widget sidebar;
  final Widget body;
  final double sidebarWidth;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onHide;
  final bool sidebarVisible;
  final double minSidebarWidth;
  final double maxSidebarWidth;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  bool _dragging = false;
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = widget.sidebarWidth.clamp(
          widget.minSidebarWidth,
          widget.maxSidebarWidth.clamp(
            widget.minSidebarWidth,
            (constraints.maxWidth - 320).clamp(
              widget.minSidebarWidth,
              widget.maxSidebarWidth,
            ),
          ),
        );

        return Stack(
          children: [
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    width: widget.sidebarVisible ? width : 0,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: width,
                        maxWidth: width,
                        child: widget.sidebar,
                      ),
                    ),
                  ),
                  Expanded(child: widget.body),
                ],
              ),
            ),
            if (widget.sidebarVisible)
              Positioned(
                left: width - 7.5,
                top: 0,
                bottom: 0,
                width: 15,
                child: Semantics(
                  button: true,
                  label: 'Resize notes sidebar',
                  hint: 'Drag to resize. Click to hide notes.',
                  child: Tooltip(
                    message: 'Drag to resize. Click to hide notes.',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      onEnter: (_) => setState(() => _hovering = true),
                      onExit: (_) => setState(() => _hovering = false),
                      child: GestureDetector(
                        key: const ValueKey('sidebar-divider'),
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onHide,
                        onHorizontalDragStart: (_) =>
                            setState(() => _dragging = true),
                        onHorizontalDragEnd: (_) =>
                            setState(() => _dragging = false),
                        onHorizontalDragCancel: () =>
                            setState(() => _dragging = false),
                        onHorizontalDragUpdate: (details) =>
                            widget.onWidthChanged(width + details.delta.dx),
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: _dragging || _hovering ? 1.5 : 0.5,
                            decoration: BoxDecoration(
                              color: _dragging || _hovering
                                  ? Theme.of(context).colorScheme.primary
                                  : palette.separator,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
