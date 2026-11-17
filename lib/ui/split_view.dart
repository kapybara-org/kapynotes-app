import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The notes list and the page: side by side, with a divider the user can
/// drag, where the window has room for both, and the list over the page where
/// it has not.
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
    this.overlay = false,
    this.minSidebarWidth = 150,
    this.maxSidebarWidth = 420,
  });

  final Widget sidebar;
  final Widget body;
  final double sidebarWidth;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onHide;
  final bool sidebarVisible;

  /// Whether the sidebar opens over the body rather than beside it, for a
  /// window with no room for both. The body keeps its whole width, dimmed
  /// behind the sidebar, which takes the keyboard from it, and a click on it or
  /// Escape hides the sidebar again through [onHide]. Nothing of the sidebar is
  /// built while it is hidden.
  final bool overlay;
  final double minSidebarWidth;
  final double maxSidebarWidth;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  /// The least of the body the sidebar leaves beside it.
  static const double _minBodyWidth = 320;

  /// The least of the body an open overlay leaves in view, for the click that
  /// closes it to land on.
  static const double _minBodyInView = 48;

  bool _hovering = false;

  final FocusNode _overlayFocus = FocusNode(debugLabel: 'sidebar-overlay');

  /// Where the divider is while it is being dragged.
  double? _dragWidth;

  bool get _dragging => _dragWidth != null;

  @override
  void didUpdateWidget(SplitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.overlay || !widget.sidebarVisible) return;
    if (oldWidget.overlay && oldWidget.sidebarVisible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _overlayFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _overlayFocus.dispose();
    super.dispose();
  }

  void _endDrag() {
    final width = _dragWidth;
    if (width == null) return;
    setState(() => _dragWidth = null);
    widget.onWidthChanged(width);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final overlay = widget.overlay;

    return LayoutBuilder(
      builder: (context, constraints) {
        final room =
            constraints.maxWidth - (overlay ? _minBodyInView : _minBodyWidth);
        double clamped(double value) => value.clamp(
          widget.minSidebarWidth,
          room.clamp(widget.minSidebarWidth, widget.maxSidebarWidth),
        );
        final width = clamped(_dragWidth ?? widget.sidebarWidth);
        final beside = widget.sidebarVisible && !overlay;

        return Stack(
          children: [
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Slides open and shut, but comes and goes at once with the
                  // room for it, rather than squeezing the body as it goes.
                  if (!overlay)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      width: beside ? width : 0,
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
            if (beside)
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
            if (overlay && widget.sidebarVisible) ...[
              Positioned.fill(
                child: ModalBarrier(
                  key: const ValueKey('sidebar-overlay-barrier'),
                  color: palette.scrim,
                  onDismiss: widget.onHide,
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: width,
                child: Actions(
                  actions: {
                    DismissIntent: CallbackAction<DismissIntent>(
                      onInvoke: (_) => widget.onHide(),
                    ),
                  },
                  child: Focus(
                    focusNode: _overlayFocus,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: palette.separator,
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: widget.sidebar,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
