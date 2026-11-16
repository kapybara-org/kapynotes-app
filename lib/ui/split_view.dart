import 'package:material_ui/material_ui.dart';

/// A two-pane layout whose divider the user can drag.
///
/// The width is owned by the caller so it can be persisted. A drag moves the
/// divider here and reports where it ended, so each frame of it lays the
/// panes out again without rebuilding them or writing the width.
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
  bool _hovering = false;

  /// Where the divider is while it is being dragged.
  double? _dragWidth;

  bool get _dragging => _dragWidth != null;

  void _endDrag() {
    final width = _dragWidth;
    if (width == null) return;
    setState(() => _dragWidth = null);
    widget.onWidthChanged(width);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double clamped(double value) => value.clamp(
          widget.minSidebarWidth,
          widget.maxSidebarWidth.clamp(
            widget.minSidebarWidth,
            (constraints.maxWidth - 320).clamp(
              widget.minSidebarWidth,
              widget.maxSidebarWidth,
            ),
          ),
        );
        final width = clamped(_dragWidth ?? widget.sidebarWidth);

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
                            setState(() => _dragWidth = width),
                        onHorizontalDragUpdate: (details) => setState(
                          () => _dragWidth = clamped(
                            _dragWidth! + details.delta.dx,
                          ),
                        ),
                        onHorizontalDragEnd: (_) => _endDrag(),
                        onHorizontalDragCancel: _endDrag,
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: _dragging || _hovering ? 1.5 : 0.5,
                            decoration: BoxDecoration(
                              color: _dragging || _hovering
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
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
